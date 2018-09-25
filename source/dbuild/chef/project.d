module dbuild.chef.project;

import dbuild.chef;
import dbuild.chef.product;

class Project
{
    private string _name;
    private Product[] _products;

    this (in string name)
    {
        _name = name;
    }

    @property Product product(in string name)
    {
        foreach (p; _products) {
            if (p.name == name) return p;
        }
        return null;
    }

    @property Product[] products()
    {
        return _products;
    }

    @property void products(Product[] products)
    {
        foreach (p; products) {
            p._project = this;
        }
        _products = products;
    }
}
